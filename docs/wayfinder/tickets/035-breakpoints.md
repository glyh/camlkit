---
status: resolved
type: decision
blocked-by: [033]
assignee: lyh
---

# Breakpoints in a session

## Question

[Stopping inside a running phrase](033-breakpoints-are-an-effect.md) decided
what a breakpoint would be and built nothing. This is the build, and the
questions it had to answer are the ones that decide what the tool surface
looks like rather than how the mechanism works.

## Decided

**The caller writes the stop.** `[%break]` is an extension point: idiomatic
for "this is rewritten", impossible to collide with a value a session defines,
and an uninterpreted one is already a compile error, so a stray marker fails
loudly. No positional breakpoints, no event-table snapping, no stepping. The
agent writes the phrase, so asking it to type a marker where it wants to stop
costs nothing and deletes the entire position-resolution layer that a person
debugging a file would need.

**Everything in scope is captured, and what cannot be bound is named.** The
locals at the marker are harvested from the typed tree, bound under a `bp_`
prefix so nothing a session holds can be shadowed, and reported as fields. A
local whose type cannot be written outside the phrase is skipped with the
compiler's own message as the reason. That check is not an analysis: the
binding is a declaration of the printed type, so a locally abstract type, an
existential or a weak variable simply fails to compile and the failure is the
answer. Measured on `let f (type a) (x : a) (y : int)`, which binds `bp_y` and
skips `x` with "Unbound type constructor a".

**A local whose type still holds a type variable is skipped too, and this one
was found the hard way.** Binding it declares a name of that type, which
generalises, so a later phrase could pick any type at all for a value that
already has one. `String.length (bp_x : string)` where `bp_x` was an int bound
at `'a` segfaulted the worker. It is skipped now, with the reason naming the
type. The instantiated type is genuinely unknown at the stop, because a
generic function is typed once and instantiated at its call sites, so there is
nothing better to bind it at. This is the same wall `#trace` hits when it
prints `<poly>`, reached from the other side.

**Parked phrases live in a table keyed by an id**, and the id may be omitted
when a session holds exactly one, which is the ordinary case. Two stops are
independent phrases, neither continuation contains the other, so refusing the
second or letting it overwrite the first would both strand a computation.

**Two tools.** `continue` resumes, or abandons with a flag, and returns an
ordinary evaluation result, or another stop if the phrase breaks again.
`inspect` binds a stop's locals again and prints them, which is how an earlier
stop is recovered after a later one took the names.

**A stop is its own response.** `Stopped` mirrors `Interrupted`: the phrases
that finished first are kept, because they really ran. Reusing `Completed`
with an extra field would let a caller reading phrases alone believe the call
finished, and reusing `Interrupted` would make a deliberate stop
indistinguishable from the deadline firing.

**A breakpoint under autorun is refused before anything runs.** Stopping
escapes the blocking run that autorun wraps a promise-typed phrase in, and the
scheduler's own guard then refuses to start another, so every later promise
phrase in the session would fail. The check is precise: the phrase was
rewritten by autorun and carries a marker. See
[Should Lwt and Async expressions auto-run](019-lwt-async-auto-run.md).

**Abandon raises, so cleanups run.** `Effect.Deep.discontinue` raises inside
the parked phrase, which is what makes a `Fun.protect` release what it holds.
Measured: the finaliser printed before the exception was reported.

## How it works, and what had to be got right

**Two rewrites, because a marker cannot be typed and its locals cannot be
known without typing.** The first turns every marker into a call with no
locals, which types; the typed tree then gives the environment at each marker;
the second rewrite starts again from the caller's own tree and inserts the
locals. The phrase is typed again afterwards, which the autorun rewrite
already required. Starting the second rewrite from the *typed* tree finds no
markers, since the first rewrite consumed them - that was the first bug and
its symptom was a stop that bound nothing.

**Only applications are generated.** `Ast_helper.Exp.tuple` changed shape
between the compiler versions this supports and `Longident.Ldot` differs too,
so the generated code builds neither a tuple nor a list: one call per local
announces it, then the stop is performed. The path to `Obj.repr` is built with
`Longident.unflatten`, as the map requires.

**The harvest is keyed on locations, not on constructors.** A typedtree
constructor's arity differs across versions; a location does not. The inserted
call carries the marker's own location as a ghost, so the environments are
found by matching those.

**Nothing is printed back to source.** Inserted nodes carry ghost locations
and existing nodes keep theirs, so the caller's line and character numbers
survive instrumentation, which is what keeps error spans and the backtrace
positions of [A raise in a phrase had no position](034-locating-a-raise.md)
honest.

**The hook is injected, not shipped.** The rewrite calls values that must
exist before the phrase is typed. They are declared by evaluating an ordinary
phrase, which gives them a type without building a value description by hand,
and the real closures are put underneath with `Toploop.setvalue`. Three
reserved names enter every session: the two hooks and the exception that
abandoning raises, which is defined in the session so the rendering says
`Camlkit_abandoned` rather than this worker's wrapped module path. Shipping an
interface file beside the worker was the alternative, rejected for the install
rules and the version-locked artefacts it would add.

## Not built

Stepping, positional breakpoints, and the shadow stack that would give a
caller's locals, all specified in
[Stopping inside a running phrase](033-breakpoints-are-an-effect.md). The
three limits recorded there stand: no breakpoint inside a prebuilt dependency,
no going back, and no stopping in a frame the runtime entered.

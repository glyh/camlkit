---
status: resolved
type: research
blocked-by: []
assignee: lyh
---

# Typecheck without running

## Question

An agent writing OCaml wants to ask two things that nothing here answers:
does this candidate typecheck against the session's real environment, and
what is the type of this expression given what the session has loaded.

`eval` answers both, and runs the code to do it. That is the wrong trade when
the code is a candidate rather than a step: it can loop, write a file, or
leave bindings behind, and the numbered `_N` accumulates whether or not the
answer was wanted. The alternative today is merlin, which answers about a
source file rather than about a session, so it cannot see a library the
session loaded or a binding the session made. There is no way to ask for the
type of an arbitrary expression against a live toplevel's environment.

## Measured

The cost is close to nothing, because the two-pass evaluation already does the
work and already restores what it touched. `typecheck_all` in `worker/eval.ml`
snapshots `Toploop.toplevel_env` before typing and restores it afterwards, and
[Protocol between server and worker](015-worker-ipc.md) made that pass exist
precisely so nothing runs unless every phrase types. Stopping after it is a
branch, not a mechanism.

## Decided

**An argument on `eval`, as the ticket leaned.** `check: true` stops after the
typecheck pass. A separate tool would have duplicated autorun, multiple
phrases, breakpoint rejection and every failure shape to change one thing.

**The result says it checked.** `checked` in `structuredContent` and a first
line in the text. The renderings differ from a run's only by the missing
`= <fun>`, which is too quiet a difference to rest a "nothing ran" on, and
this follows the precedent set for autorun, where a rewrite is reported
because it is otherwise invisible.

**What comes back is the signature the phrase typed to,** printed with
`Printtyp.signature` inside `Printtyp.wrap_printing_env`, which is how the
toplevel prints one. So `val f : int -> int` where a run says
`val f : int -> int = <fun>`.

**The implicit counter does not advance,** so the `_N` a check reports is the
name the same code really gets if it is run next. Measured through the tool
surface: a check reports `val _0 : int`, and the eval after it reports
`val _0 : int = 42`.

**Bare expressions are still bound before typing.** `Pstr_eval` has an empty
signature, so without the existing `bind_expressions` rewrite a checked
expression would report nothing at all, which is half the question the ticket
asked. Measured in a session: `1 + 1;;` typed directly gives `""`.

**Warnings come from the typecheck pass,** captured per phrase by swapping
`Location.formatter_for_warnings` around each typing. A check raises the same
`Warning 8` a run does.

## Found on the way

The typecheck passes were writing their warnings to the worker's stderr, which
is the captured-output file, so a warning arrived in a result up to five times:
once in `warnings` and four times in `output`. Capturing the two typecheck
passes takes it to three. The remaining two copies come from the execute pass
and are not understood yet;
[A warning arrives several times over](050-a-warning-arrives-several-times-over.md)
has the measurement.

## Open

**An argument on `eval`, not a tool.** "A call says only what is unusual" says
`check` belongs beside `autorun`. Against: it makes `eval` a tool that
sometimes does not evaluate, and every result then has to say which it was.
Leaning towards the argument anyway, because a separate tool would duplicate
the whole eval surface - autorun, several phrases, the same failure shapes -
to change one thing.

**What comes back.** The types, presumably, in the shape `eval` already uses
for a rendering, so a caller reads `val f : int -> string` exactly as it would
after running. A failure is already structural, with spans and line ranges, so
nothing new is needed on that side.

**Whether the implicit `_N` counter advances.** It must not: a check that
consumed a name would make the numbering depend on calls that ran nothing.
The counter only advances after the second pass, so this falls out, but it is
the thing to get wrong.

**Whether autorun still rewrites.** A checked phrase should be typed as the
phrase that would run, or the check answers about different code than the
caller would get. That means the rewrite happens and its rule is reported,
which is what the first pass does already.

Covered by "check runs nothing" in the worker suite, which checks the type
comes back without a value, that the phrase printed nothing, that the binding
does not exist afterwards, that the counter did not move, that a type error is
still a typecheck failure, and that warnings survive.

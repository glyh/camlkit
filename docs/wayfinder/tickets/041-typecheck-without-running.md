---
status: open
type: research
blocked-by: []
assignee:
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

---
status: open
type: defect
blocked-by: [036]
assignee:
---

# context lost the wrapper

## Symptom

`context` on `lib/render.ml`, a file in this project's own wrapped library,
answers with one line:

    open Wire;;

That is the file's own `open`, and nothing else.
[Evaluating in a file's context](036-a-file-s-context.md) specified three
things: dune's `-open` for a wrapped library, the file's own opens, and the
file's own module last. Two of the three are missing. The expected answer ends
`open Camlkit.Render;;`.

The wrapper half is the one a reader cannot guess, which is the reason the
tool exists at all. Without it a session evaluating in that "context" cannot
see any sibling module by its short name, and the failure is an `Unbound
value` that looks like the caller's mistake.

## Not merlin

merlin has the answer and is being asked correctly. `ocamlmerlin single
dump-configuration` on that file reports

    "open_modules":["Camlkit"]

so the data is present in the reply that `lib/context.ml` already reads. The
library is genuinely wrapped: `_build/default/lib/.camlkit.objs/byte` holds
`camlkit__Render.cmi` beside `camlkit.cmi`.

## How it was found

`scripts/load-check.py` checks this, because a wrapped library needs a real
dune project and so is out of reach of `dune test` for the same reason the
load half is. It has been failing. Noticed while resolving
[A failed dune top degrades in silence](040-a-silent-fallback.md), which is
unrelated to it; the failure predates that work, confirmed against the build
before it.

## Open

**Whether the reading of `open_modules` broke or never worked for this shape.**
The script encodes the expected answer, so it presumably worked when 036
landed. Bisecting it is the first move, not re-deriving the logic.

**Whether the file's own module is a separate loss.** Two things are missing
and they have different sources: `open Camlkit` comes from merlin's
configuration, `open Camlkit.Render` is computed from the file's own path and
its library's wrapper name. They may not share a cause.

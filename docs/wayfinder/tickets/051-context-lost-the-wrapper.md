---
status: resolved
type: defect
blocked-by: [036]
assignee: lyh
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

## Cause, which is not where this ticket first looked

Not `context`, and not its reading of merlin's reply. Both are correct. The
trigger is how the caller spelled the path.

Every merlin query runs in the file's own directory, because that is how
merlin finds a project's configuration. A relative path does not survive that
`cd`: merlin is then asked about a filename that no longer resolves from where
it now stands. It does not refuse. It answers without the project's
configuration, so `dump-configuration` comes back with no `open_modules` at
all and `context` correctly reports the nothing it was given.

The same file, three spellings, before the fix:

    ./lib/render.ml                 opens: Wire
    lib/render.ml                   opens: Wire
    /home/.../lib/render.ml         opens: Camlkit, Wire, Camlkit.Render

`scripts/load-check.py` passes `.` as the project and joins from it, so it had
been asking with a relative path all along. It is left that way deliberately:
it is what caught this.

Commands needing only the source on stdin were unaffected, which is what kept
it quiet. `outline` on a relative path answers correctly, so the surface did
not look broken.

## The fix

One resolution in `lib/merlin.ml`, applied in `query`, `read_file` and
`ensure_index`, so the `cd`, the `-filename` and the source all refer to the
same file however a caller spelled it. Resolved there rather than at the tool
boundary because every merlin-backed tool shares those three, and fixing the
two that were visibly wrong would have left the rest waiting.

## What the ticket guessed, and did not find

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

**It never broke, so there was nothing to bisect.** The ticket assumed a
regression because the script encodes the expected answer and the script was
failing. The answer was always right for an absolutely-spelled path, which is
how the tool is normally called.

**The two missing opens did share a cause after all,** which the ticket
doubted. `open Camlkit` comes from merlin's configuration and
`open Camlkit.Render` is computed from the wrapper name, but the second is
derived from the first, so losing the configuration loses both.

## No test in the suite

The regression stays in `scripts/load-check.py`. Catching it needs a real dune
project with a wrapped library, and `test/fixtures/mylib` is a findlib
directory with a `META` rather than one. A temp file in no project would
exercise the path handling and could not fail on this bug, which is worse than
not testing it.

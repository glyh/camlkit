---
status: resolved
type: defect
blocked-by: [054]
assignee: lyh
---

# load replaces the user's OCAMLPARAM

## Symptom

load runs `dune top` with `OCAMLPARAM=_,ppx=<worker> --swap-ppx,w=-a` (see
[Swapping a function in a loaded project](054-swapping-a-function-in-a-loaded-project.md)),
which replaces any OCAMLPARAM the user had set rather than adding to it. Not
measured on a project that depends on one.

Two smaller edges of the same variable: OCAMLPARAM separates settings with
commas, so a worker installed under a path containing a comma breaks the ppx
setting; and a ppx path is run through the shell, so it is quoted.

## Direction

Prepend to an existing value after its `_` marker rather than replacing it,
and refuse a worker path with a comma with a message naming it.

## Decided

**Merged, in `Wire.Exe.ocamlparam`, which is pure and tested.** The value is
read as `driver/compenv.ml` reads it. A leading `:`, `|`, `;`, space or comma
picks the separator, and exactly one `_` splits the settings applied before the
command line from those applied after. The user's settings are kept on both
sides and ours are appended after the `_`, so `w=-a` has the final word.

**A value the compiler would refuse is dropped.** That is a value with no `_` or
with two. The compiler prints an error and ignores all of it, so the result is
the same minus the error it would print for every file.

**The separator is chosen, not a comma refused.** The first of `,` `|` `;` `:`
that appears in no setting is used, which the compiler allows for exactly this
reason. Only a path containing all four is an error, and it comes back as the
load's `Dune_failed` naming the settings. The space is not a candidate because
the ppx setting contains one.

The ppx path was already quoted. Checked end to end with
`OCAMLPARAM=_,g=1` through `scripts/load-check.py`: load, context and swap all
pass.

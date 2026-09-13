---
status: open
type: defect
blocked-by: [054]
assignee:
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

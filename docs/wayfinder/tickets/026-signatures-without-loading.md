---
status: open
type: research
blocked-by: []
assignee:
---

# Module signatures without loading

## Question

`describe` answers from the live toplevel, so it only sees what a session has
loaded. Asking what is in a library means loading it first, which needs the
project built and the right switch.

[ocaml-mcp](https://github.com/tmattio/ocaml-mcp) reads signatures from
compiled artifacts instead, and its TODO sketches a fuller ladder: use merlin
if the module is part of the project; look in `_build/private/.pkg` if the
project uses dune package management; look at the installed files through
findlib otherwise; and fall back to `docs-data.ocaml.org` for a package that
is not installed at all.

Establish which rungs are worth having here. The last one reaches a network
service, which is a different trust posture from everything else this does
and should not be adopted without deciding that deliberately.

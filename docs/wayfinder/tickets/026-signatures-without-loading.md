---
status: open
type: research
blocked-by: [027]
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

## Decided

**Local rungs only. No network.** Reaching `docs-data.ocaml.org` would make
this the one part of the server that talks to the network, and
[Trust boundary](012-trust-boundary.md) rests on everything staying beside
the person who launched it. A signature for a package you have not installed
is not worth changing that.

**Blocked on merlin**, which is the first rung: once
[Merlin-backed source queries](027-merlin-source-queries.md) lands, project
modules are covered and `describe` covers anything a session has loaded. What
remains is the installed-but-not-loaded case through findlib, which may turn
out to be small enough not to need a ticket at all.

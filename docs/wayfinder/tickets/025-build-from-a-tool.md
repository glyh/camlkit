---
status: open
type: grilling
blocked-by: []
assignee:
---

# Building the project from a tool

## Question

The edit-build-reload loop is one call only after the build has happened
elsewhere. An agent editing a file must leave this server, run `dune build`
some other way, and come back. A build tool would close the loop.

[ocaml-mcp](https://github.com/tmattio/ocaml-mcp) exposes three:
`dune/build-status`, `dune/build-target` and `dune/run-tests`, via Dune RPC
rather than by shelling out, which gives structured diagnostics rather than
scraped text.

Decide whether this belongs here at all. The argument for: the loop is the
point, and `load` already shells out to `dune top`, so the dependency exists.
The argument against: an agent already has a shell, and a build tool that
only wraps one is a tool competing for attention without adding capability.
Dune RPC changes that calculus, because structured diagnostics are something
a shell does not give.

Its own TODO notes that a build needs a timeout, which we would get from the
existing deadline.

---
status: open
type: defect
blocked-by: [027]
assignee:
---

# A built index is not a populated one

## Symptom

`uses` at project scope needs dune's occurrence index, and merlin says
nothing when it is missing: it answers from the current buffer alone and
reports `class: return`, so a caller reads a complete-looking list that omits
every use in every other file. `lib/merlin.ml` documents exactly this and
builds the index first because of it.

What it checks is the exit status of `dune build @ocaml-index`. A zero exit
means dune had nothing to complain about, which is not the same as an index
with occurrences in it. When the two differ, `uses` is back to the failure
the index build was added to prevent, and reports `incomplete` only when dune
failed outright.

## Where they differ

The occurrence data the index is built from is written by the compiler, and
only by OCaml 5.2 and later. camlkit's own switch is 5.3 or newer by
`dune-project`, but the merlin tools need no session and no compatible
bytecode: `uses` runs against whatever project it is pointed at, including
one on 4.14, where the archives could never be loaded into a session anyway.
The index alias on such a project does not have to fail in order to produce
nothing.

Measured on this project, on dune 3.24.1 and OCaml 5.4.0: before the call
there were no `.ocaml-index` files under `_build/default`, after
`dune build @ocaml-index` there were five, and the exit status was zero in
the same way it would be for a project that produced none.

## The check

Whether any `.ocaml-index` file exists under the build directory after the
build. That is one directory walk on a path `Wire.Exe.project_root_of`
already found, and it answers the question the exit status only approximates,
without needing to know why the index is empty - an old compiler, a dune too
old for the alias, a tree that was never built.

## Prior art

From `mina-agent`, whose `mina_agent/usages.py` hit this on a 4.14 tree and
gave up on merlin for it entirely: it compiles a small `compiler-libs`
program that reads the `.cmt` files directly, computes the search scope from
a derived dune graph, and reports the occurrences out of the typed trees,
which hold every resolved reference regardless of compiler version. That is
the right answer for a project pinned to 4.14 and the wrong one here, where
the switch is 5.3 or newer and merlin already answers - it would add a second
implementation of `uses`, a compiled helper binary and a dependency graph, to
serve a project this server cannot start a session for. What transfers is the
finding, not the workaround.

## Open

**What the caller is told.** `uses` already has an `incomplete` field
carrying dune's reason, from the same route, so an empty index fits there
with a reason of its own. The wording matters more than the mechanism: it has
to say the answer covers this file only, because that is the thing a caller
would otherwise act on wrongly.

**Whether the scope argument should refuse.** A caller that asked for project
scope and can only be given buffer scope has asked for something unavailable.
Answering with buffer scope plus a field is consistent with the rest of the
surface; refusing would be defensible and is a worse fit for a tool whose
partial answer is still useful.

**Whether the index build should be skipped when it cannot help.** Nothing
is lost by trying - it is 0.2 s on a built project - and skipping it needs
the compiler version, which is one more thing to find out. Probably not.

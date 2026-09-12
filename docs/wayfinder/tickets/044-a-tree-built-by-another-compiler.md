---
status: open
type: defect
blocked-by: []
assignee:
---

# A tree built by another compiler says only "not a bytecode object file"

## Symptom

`load` reads a project's `_build`. The worker is bytecode and bytecode is
version-locked to the compiler that produced it, so a tree built by a
different OCaml cannot be loaded at all. What a caller is told, measured by
patching a real archive's magic from `Caml1999A036` to `Caml1999A035` and
loading it:

    File .../bad.cma is not a bytecode object file.

That is the whole message. It does not say the file is a bytecode object
file, only one from another compiler; it does not name either version; and it
arrives once per archive, so a project of thirty libraries reports thirty
copies of a sentence that names no cause.

`worker/loader.ml`'s `annotate` adds nothing here. It reasons from
`missing_unit`, which matches "Reference to undefined global", and this error
has no unit in it. So the one place that turns an opaque loader failure into
a diagnosis is silent for the failure that is hardest to guess.

Reaching it does not take a second switch on purpose. Rebuilding the project
after an `opam switch create`, a compiler upgrade, or building it once under
nix and once under opam all produce it, and none of those look like a
mistake at the time.

## Cause

Nothing compares the tree against the worker. `Topdirs.dir_load` checks the
magic and reports a mismatch as a bad file, because from inside the loader
that is all it is.

## The check

`Config.cma_magic_number` is the worker's own answer, and an archive's first
twelve bytes are the tree's. Confirmed on this switch: the string in
`_build/default/lib/camlkit.cma` is `Caml1999A036` and
`Config.cma_magic_number` is the same, alongside `Config.version` 5.4.0.

So one read of twelve bytes, against a constant already linked in, decides
it. `Config.version` gives the worker's version for the message; the tree's
version is not recoverable from the magic alone, which is a number rather
than a version, so the honest sentence names ours and says the tree's
differs.

## Prior art

Borrowed from `mina-agent`, a sibling harness for the Mina monorepo, which
carries the same idea with a different mechanism: `mina_agent/env.py` reads
the first `ocamlc -config` line out of `_build/log` and classifies the
compiler that produced the tree as nix, opam or unknown, then compares it
with the toolchain the harness itself reaches. The idea transfers; the
mechanism does not. That harness pins dune 3.3.1, and dune 3.24.1 here
writes no `_build/log` at all - `_build` holds `.db`, `.digest-db` and
`.actions` instead. The magic number is a better source anyway, because it
is what the loader actually rejects on rather than a record of who ran the
build.

## Open

**Where the check goes.** Once per `load`, against the first archive it is
about to try, is enough: a tree is built by one compiler. Per archive would
repeat the work and the sentence.

**Whether it is a failure or a field.** A mismatch means nothing in the tree
can load, so it is closer to `build_root` failing than to one archive
failing. Reporting it as the load's own error, naming the worker's version
and the project directory, says more than thirty annotated archive failures.

**Whether `require` needs it too.** Findlib archives come from the worker's
own switch, which is by construction the right one, so probably not. A
`CAMLKIT_SWITCH` pointed at a switch of another version is the exception, and
[dune cannot see the switch a client did not pass on](039-dune-in-a-bare-environment.md)
already documents that as unsound rather than defending against it.

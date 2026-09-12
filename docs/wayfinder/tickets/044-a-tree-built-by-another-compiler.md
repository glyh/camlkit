---
status: resolved
type: defect
blocked-by: []
assignee: lyh
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
twelve bytes are the tree's. One read, against a constant already linked in,
decides it. `Config.version` gives the worker's version for the message; the
tree's version is not recoverable from the magic alone, which is a number
rather than a version, so the honest sentence names ours and says the tree's
differs.

**Correction to this ticket's own measurement.** It claimed `Caml1999A036` and
`Config.version` 5.4.0. Both are wrong. This switch is OCaml 5.3.0, its magic
is `Caml1999A035`, and the archives under `_build` carry that. The 5.4.0
reading came from a probe compiled outside the switch the worker is built in,
which is the very mistake
[dune cannot see the switch a client did not pass on](039-dune-in-a-bare-environment.md)
is about, made while writing a ticket about version mismatch. It cost a debugging
detour: the first foreign tree was faked by patching A036 to A035, which on
this switch patched the magic to the one it already had, so the check appeared
not to fire when it was working correctly. Ask the worker, not a probe.

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

## Decided

**Checked once per load, against the first archive it is about to try,** in
both routes: the archives dune named, and the scan for a directory that is not
a dune project. A build tree is built by one compiler, so one archive decides
it.

**Reported as the load's own failure,** not as an annotation on each archive.
A mismatch means nothing in the tree can load, which is closer to the build
root being missing than to one library failing, and the old behaviour repeated
a causeless sentence once per archive.

**An archive too short or unreadable to say is not a mismatch.** It is a
broken file, and the loader's own report of that is better than a guess about
switches.

Measured through the tool surface, against a tree whose magic was patched to a
genuinely different compiler's:

    <path> was built by a different OCaml than this worker, so nothing under
    it can be loaded. This worker is bytecode from OCaml 5.3.0, and bytecode
    only loads archives its own compiler produced. Rebuild the project in that
    switch, or point CAMLKIT_WORKER at a worker built in the project's.

against what it used to say, which was `File <path> is not a bytecode object
file.` once per archive.

## Open

**No case in `dune test`.** Producing a foreign tree means writing a patched
archive, and the load path is out of reach of `dune test` anyway, since it
shells out to `dune top` and dune will not run inside dune. Not added to
`scripts/load-check.py` either: that script checks a real project, and having
it fabricate a corrupt archive would make its failures harder to read. Verified
by hand, quoted above.

**Whether `require` needs it too.** Findlib archives come from the worker's
own switch, which is by construction the right one, so probably not. A
`CAMLKIT_SWITCH` pointed at a switch of another version is the exception, and
[dune cannot see the switch a client did not pass on](039-dune-in-a-bare-environment.md)
already documents that as unsound rather than defending against it.

---
status: resolved
type: defect
blocked-by: []
assignee: lyh
---

# dune cannot see the switch a client did not pass on

## Symptom

A client that launches the server without the opam environment gets a partial
load that blames the wrong thing:

    load { path = <this project> }
      -> loaded: wire, mylib
         failed: camlkit — Reference to undefined compilation unit `Jsonrpc'
                 Jsonrpc is not built by this project, so it comes from an
                 external library. Load it with the require tool first.

Nothing there is true of the project. `jsonrpc` is a perfectly ordinary
dependency that `dune top` would have named, `mylib` is a test fixture that
has no business in a session, and the hint sends the caller to `require` for a
package that was never the problem.

Seen through a real MCP client rather than reasoned about. The user's shell
does not carry `opam env`, which the commands section of CLAUDE.md has always
said, and a client inherits that shell.

## Cause

`dune top` needs findlib to resolve a project's external dependencies, and
findlib is reached through the environment, not through dune's own path.
Measured, running the switch's dune with nothing but `/usr/bin` on PATH:

    dune top .   ->  Error: Library "yojson" not found.
                     -> required by library "camlkit" in _build/default/lib
                     exit 1

Adding the switch's bin directory to PATH is enough on its own:

    PATH=<switch>/bin:/usr/bin dune top .   ->  the directives, correct

So the worker finds the right dune - [C stubs in a bare environment](028-c-stubs-in-a-bare-environment.md)
and `Wire.Exe.find` already solved finding binaries - and then hands it an
environment in which it cannot work. The same applies to the `dune build
@ocaml-index` that `uses` runs, measured to fail identically.

**merlin is unaffected**, which is worth recording because it looks like it
should not be. It reads dune's cached configuration rather than resolving
packages, so in the same bare environment it still reports the right
`open_modules` and a full build path, with no failures. Every merlin-backed
tool, `context` included, keeps working.

## Fixed

**Both processes adopt their own switch at startup**, in `Wire.Exe.adopt_switch`,
called before anything is spawned or shelled out to. Children inherit it, so
there is no call site left to forget: the worker's `dune top` and the server's
merlin and index build are all covered by one line in each `main`.

**Derived from our own path, not from running `opam env`.** Three reasons, and
the third is the one that matters. `opam` is not installed into the switch - it
lives in `/usr/bin` here - so it may not be there to run. It costs a subprocess
on a path that already shells out. And without `--switch` it answers for the
shell's switch, which is exactly the switch that is wrong: what matters is the
one these binaries were installed into, because the worker's bytecode is
version-locked to the compiler that built it.

**PATH and `OPAM_SWITCH_PREFIX`, and deliberately nothing else.** PATH is what
was measured to fix it, twice: dune finds ocamlfind through it and needed
nothing more. PATH is prepended, so this switch wins over whatever the client's
shell had, and the prepend is idempotent.

**`CAML_LD_LIBRARY_PATH` is deliberately not set**, which is the interaction
with [C stubs in a bare environment](028-c-stubs-in-a-bare-environment.md).
That ticket decided against setting the variable, because a user may have set
it deliberately, and reached the same end through `Dll.add_path` inside the
worker. Setting it here would overrule that decision, and would not help
anyway: the runtime reads it when a process starts, so a `putenv` afterwards is
too late for this process and reaches only children, which do not load our
stubs. The toplevel path variables are out for a related reason - the only
toplevel here is the one inside the worker, configured through findlib.

**`CAMLKIT_SWITCH` overrides the switch**, as `CAMLKIT_WORKER` overrides the
worker. It is validated the same way the derived prefix is, by looking for
`lib/ocaml` under it, and a value that is not a switch is refused on stderr
rather than silently used. **Sound only for a switch with the same OCaml
version**: the worker is bytecode from the switch it was built in, so another
switch's artifacts will not load. The README says so.

**Adoption is refusable, for nix.** `CAMLKIT_SWITCH=none`, or empty, adopts
nothing and inherits the environment as given. A project whose toolchain comes
from nix has it on `PATH` already, and its prefix is a store path rather than a
switch, so prepending anything would be at best pointless. Both spellings are
accepted because an empty value is what a shell produces by accident from an
unset variable, and `none` is what someone writes on purpose.

**A build tree is not a switch.** In development the derived prefix is
`_build/default`, which has no `lib/ocaml`, so nothing is adopted and the
environment a developer already has under `opam env` is left alone.

## Checked

Measured end to end with `scripts/load-check.py` under `env -i`, which is the
failure as reported:

    bare, no switch      -> loaded 2 libraries: wire, mylib          FAIL
    bare, CAMLKIT_SWITCH -> loaded 4: wire, yojson, jsonrpc, camlkit PASS
    good PATH, =none     -> loaded 4: wire, yojson, jsonrpc, camlkit PASS
    bare PATH,  =none    -> loaded 2 libraries: wire, mylib

The last two are the opt-out doing exactly nothing in both directions: it
inherits a good environment and it declines to repair a bad one.

The pure halves have unit tests: PATH prepends exactly once, the variable list
holds the switch prefix and nothing that would tread on ticket 028, and a
directory with no stdlib under it is not a switch.

## Still open

The honest answer for `uses` already existed: it reports `complete: false`
with a caveat when the index cannot be built, per
[Merlin-backed source queries](027-merlin-source-queries.md). `load` has no
such report, and this fix removes the common cause without removing the
silence. See
[A failed dune top degrades in silence](040-a-silent-fallback.md).

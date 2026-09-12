---
status: open
type: defect
blocked-by: []
assignee:
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

## Not yet decided

Whether the fix is PATH alone or the switch's whole environment. PATH was
measured sufficient here, but `opam env` also sets `OCAMLPATH`,
`CAML_LD_LIBRARY_PATH` and `OPAM_SWITCH_PREFIX`, and a switch that is not the
default may need more than the binary directory to be found first. Prefer the
smallest thing that is measured to work across a non-default switch.

Where it goes: `Wire.Exe` already owns "find the binary beside us", and this is
the same knowledge one step further on, so probably a function there that
returns the environment to run a switch binary under, used by both dune
call sites.

Note that the honest answer for `uses` already exists: it reports `complete:
false` with a caveat when the index cannot be built, per
[Merlin-backed source queries](027-merlin-source-queries.md). `load` has no
such report, which is
[A failed dune top degrades in silence](040-a-silent-fallback.md).

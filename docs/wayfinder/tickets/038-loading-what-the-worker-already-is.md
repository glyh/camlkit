---
status: resolved
type: defect
blocked-by: [021]
assignee: lyh
---

# Loading what the worker already is

## Symptom

`load` on this project reported success, and the session then died on the
next phrase:

    load { path = <camlkit root> }   -> loaded 11 libraries: yojson, wire,
                                        jsonrpc, unix, str, camlkit, findlib,
                                        findlib_top, ocamlcommon,
                                        ocamlbytecomp, ocamltoplevel
    Yojson.Safe.from_string "1";;    -> the worker died during evaluation

Nothing was printed to stderr, so the report named the wrong thing: it looked
like a fault in the phrase rather than in the load before it.

## Cause

`dune top` names every external a project depends on, and
[Loading a dune project's own libraries](021-dune-aware-load.md) loads all of
them. Some of those externals are what the worker is itself built from, so the
load re-initialises modules the running toplevel is made of.

Bisected by loading cumulative prefixes of dune's own order. Every prefix
through `ocamlbytecomp` was fine and the session survived; adding
`ocamltoplevel` killed it. Loading `ocamltoplevel.cma` alone was also fine,
so it is replacing the live `Toploop` under a matching `ocamlcommon` and
`ocamlbytecomp` that does it, not any one archive.

The first symptom seen was `Yojson`, which is misleading: yojson is duplicated
too, and survives duplication. Any phrase would have died.

This reaches any project depending on compiler-libs, not only this one.

## Fixed

An external archive the worker already contains is skipped. The list is the
worker's own libraries, five package names kept beside `worker/dune`, expanded
through findlib rather than written out, so `compiler-libs.toplevel` brings
`ocamlcommon` and `ocamlbytecomp` without anyone naming them and the list
cannot drift into naming an archive that moved.

**Only archives from outside the project.** A project may have a library of
its own called `str`, and that one has to load. The paths `dune top` prints
are absolute, so the guard is a prefix test against the project root.

**`require` had the same hazard**, and it is the same list: the worker
declared only `compiler-libs.toplevel` to findlib as already loaded, so
`require yojson` reloaded a yojson that was already in the binary. It survived,
as the loader's duplicate did, but for no better reason. `Topfind.don't_load_deeply`
now takes the whole list.

**Not fixed: the project's own libraries.** Loading camlkit into camlkit still
reloads `wire`, which the worker links, because it comes from the build tree
and the guard deliberately does not reach there. It survives, and the only
project affected is this one.

## Checked

`scripts/load-check.py`, for the reason cancellation has a script: the load
shells out to `dune top`, and dune refuses to run inside another dune, so
`dune test` cannot reach this path. The script loads a project and evaluates
`Location.none`. It fails on the code before the fix and passes after.

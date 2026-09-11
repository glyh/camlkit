---
status: resolved
type: defect
blocked-by: []
assignee: lyh
---

# C stubs are unreachable in a bare environment

## Question

`require { packages: ["lwt.unix"] }` kills the worker and loses the session,
from an installed server started the way a client starts it. `lwt` alone
loads. So does `str` and `unix`. Only a package carrying C stubs fails.

The README claims the opposite, and names this exact case:

> Nothing else needs opam at runtime. [...] findlib's configuration is
> compiled in, so `require` works from a bare environment. Verified with
> `PATH=/usr/bin:/bin` and no opam variables set.

That verification cannot have covered a package with stubs.

## What happens

The worker redirects its own stderr into the capture file, which is unlinked
at startup, so the failure is invisible from outside. Holding a descriptor on
that file the way the server does shows it:

```
/home/lyh/.opam/utop-mcp-53/lib/lwt/unix/lwt_unix.cma: loaded
Cannot load required shared library dlllwt_unix_stubs.
Reason: dlllwt_unix_stubs.so: cannot open shared object file:
  No such file or directory.
Fatal error: exception Compenv.Exit_with_status(125)
```

The worker exits 2. The server reports `the worker died during evaluation;
session state is gone`, which is true and says nothing about why.

## Cause

Two independent defects, and the second is the one that matters more.

**The stub path is wrong, and opam normally hides it.** `ld.conf` in the
switch names `<switch>/lib/ocaml/stublibs`, while opam installs package stubs
into `<switch>/lib/stublibs`, one level up. Nothing in the compiled-in
findlib configuration bridges the two. `opam env` sets
`CAML_LD_LIBRARY_PATH=<switch>/lib/stublibs`, so every environment that has
ever run `eval $(opam env)` works, and a bare one does not.

Measured on switch `utop-mcp-53`, OCaml 5.3.0, lwt 6.1.2, at `62aa167`:

| Environment | `require lwt.unix` |
| --- | --- |
| bare | worker dies, session lost |
| `CAML_LD_LIBRARY_PATH=<switch>/lib/stublibs` | ok, `loaded: ["lwt.unix"]` |

The same switch's plain `ocaml` toplevel loads `lwt.unix` fine, but only
because it was reached through `opam exec`, which sets the variable. It is
not a worker-versus-toplevel difference.

**A dynlink failure escapes and takes the session with it.**
`Eval.require_packages` catches `Fl_package_base.No_such_package`,
`Fl_package_base.Package_loop` and `Failure`. A missing stub raises
`Compenv.Exit_with_status`, which is none of those, so it propagates out of
the request loop and the process ends. This is worth fixing regardless of the
path problem: `require` already has a shape for reporting a package that did
not load, the `failed` list, and any load failure belongs in it rather than
in a dead worker. Note that `load` shares `require_packages`, so it has the
same hole.

## Why it was not caught

The same reason as [Making it installable](020-installability.md), one layer
further out. The installed server was driven from an unrelated working
directory, which is what that ticket set out to check, but from a shell that
had opam's environment. `PATH=/usr/bin:/bin` removes opam from the path
without removing `CAML_LD_LIBRARY_PATH` from the environment, and unsetting
opam's *variables* is not the same as unsetting that one, which is the only
one that matters here.

The test suite cannot see it either: tests run under `dune`, which runs under
opam's environment.

## Resolution

Both changes made, at `worker/eval.ml`. The second alone is enough to stop
losing sessions.

1. Catch every exception out of the findlib load, not three named ones, and
   report it through `failed`. A package that cannot load is a result, not a
   crash.

2. At worker startup, if `CAML_LD_LIBRARY_PATH` is unset, derive the stub
   directory from findlib's compiled-in configuration rather than from the
   environment. `Findlib.config_var "destdir"` gives `<switch>/lib`, whose
   `stublibs` is where the stubs actually are. Prefer adding it to the
   existing search path over overwriting a variable the user may have set
   deliberately.

What was done: `require_packages` now catches every exception, not three
named ones, and appends the captured stderr to the message, since neither the
`failed` list nor a `load` failure carried the toplevel's own detail back.
`Eval.init` adds `Findlib.default_location ()/stublibs` through `Dll.add_path`,
which is what `#directory` uses for the bytecode dll search, rather than
setting a variable the user may have set deliberately.

The README's bare-environment claim was re-verified against `lwt.unix` in an
empty environment and now names the stub case.

Measured after the fix, from `env -i PATH=/usr/bin:/bin`, with the repro
below pointed at the build tree:

| Worker | `require lwt.unix` |
| --- | --- |
| fixed | `loaded: ["lwt.unix"]` |
| stub path removed, exception fix kept | `failed`, naming the shared library, session alive |

No test covers this: `dune test` runs under opam's environment, which is the
one environment where the defect cannot appear. The repro below is the
check.

## Reproducing it

From any environment, with a switch path substituted:

```sh
S=/home/lyh/.opam/utop-mcp-53
R='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"require","arguments":{"session":"x","packages":["lwt.unix"]}}}'

{ echo "$R"; sleep 6; } | env -u CAML_LD_LIBRARY_PATH $S/bin/utop-mcp
{ echo "$R"; sleep 6; } | env CAML_LD_LIBRARY_PATH=$S/lib/stublibs $S/bin/utop-mcp
```

To see the worker's own error rather than only that it died, open the capture
path before spawning the worker and read it after the worker exits; the
worker unlinks the name, so the descriptor is the only way back to it.

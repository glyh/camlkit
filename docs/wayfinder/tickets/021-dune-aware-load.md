---
status: closed
type: prototype
blocked-by: []
assignee: lyh
---

# Loading a dune project's own libraries

## Question

Reported from a session using this against a real compiler project: the
tool works, `describe` in particular, but reaching the project's own code
took about six calls of ceremony before the first useful one. `require`
only does findlib, and a dune project's libraries are usually private, so
the session had to `require "compiler-libs.toplevel"` and then call
`Topdirs.dir_directory` and `Topdirs.dir_load` by hand, while knowing that
dune hides the `.cmi` files under `.<lib>.objs/byte`.

The mechanism is confirmed to work, by hand, in that project's own switch:

```
#directory ".../lib/core_kernel/.core_tt_kernel.objs/byte";;
#load      ".../lib/core_kernel/core_tt_kernel.cma";;
#show Compiler_names;;   → module Compiler_names : sig ... end
```

Design a `load` tool that takes a dune project root and does this: discover
the `.cma` files under `_build/default`, add each one's `.objs/byte`
directory to the search path, and load them. Dependency order matters, and
a fixpoint retry over the discovered set is probably cheaper than parsing
dune's package metadata.

**Reload after a rebuild must reset first.** Reported from a second session:
editing a file, running `dune build`, and re-loading the `.cma` fails with
`Compenv.Exit_with_status 125` from an interface checksum mismatch, because
the old `.cmi` is already loaded. So the edit-build-test loop currently
costs a `reset` plus a full manual reload every time. The tool should
remember a session's load sequence and offer a reload that resets and
replays it; that is what would make this usable for compiler work rather
than one-shot exploration.

Two constraints found while confirming it. The worker must be built in the
same switch as the project, because bytecode is version-locked. And this
cannot be folded into `eval`: changing the search path and using a module
from it in the same call fails, since nothing runs unless every phrase
typechecks first. That behaviour is pinned by a test.

## Resolution

Implemented as the `load` tool, backed by `worker/loader.ml`. It takes a
project root, finds the `.cma` archives under `_build/default`, adds each
one's `.<lib>.objs/byte` directory to the search path, and loads them.

**Dependency order settles itself.** Rather than parsing dune metadata, a
failed archive is retried until a pass makes no progress. Verified against a
real compiler project: seven interdependent libraries loaded from one call,
in an order the caller never had to know.

**The real error is surfaced, not the exception.** `Topdirs.dir_load`
usually reports by printing to its formatter and sometimes raises, and the
exception alone is useless: `Symtable.Error(_)`, or the
`Compenv.Exit_with_status 125` reported from a session. Both the formatter
text and the exception rendered through `Errors.report_error` are captured,
which turns that into `Reference to undefined compilation unit 'Sedlexing'`.

**External dependencies are named rather than guessed at.** dune records no
machine-readable requires for private libraries, so they cannot be resolved
automatically. When a missing unit is not built by the project, the error
says it is external and to use `require` first. Confirmed on a project whose
lexer needs `sedlex`: requiring it and loading again took all seven
libraries.

**Reload after a rebuild is a `reset` flag on the load.** It discards the
session server-side before the request reaches a worker, so the stale
interfaces are gone rather than conflicting. No per-session load history is
needed, because the request already carries everything required to replay it.

## Amendment: two things the first version got wrong

Both reported from a session using it on a real project.

**A reset wiped the findlib packages the load needed.** The rebuild loop was
three calls (reset, require, load) because emptying the session also emptied
what it had required, and `core_tt_syntax` cannot load without `sedlex`. The
server now remembers what a session was told to require and replays it as
part of a reset-load, so the loop is one call. An explicit `reset` still
forgets them, because there "empty" is the whole point. The restart note is
also suppressed for a requested reset: it claimed the packages were gone
while the same call was putting them back.

**The cascade messages blamed the wrong thing.** A failure naming
`Raw_syntax` reported it as an external library, because the check compared
the missing *module* name against *archive* names. Every module of this
project failed that test, so four knock-on failures each looked like a
separate missing dependency and only one was real. The missing unit is now
matched against the `.cmo` files in each discovered library's objs
directory, so it says "comes from core_tt_syntax, which failed above; this
is a knock-on failure" and points at the single genuine error.

## Amendment: say that the reset happened

Suppressing the generic restart note on a requested reset was an
overcorrection. The note was wrong, because it claimed the required packages
were gone while the same call restored them, but removing it left a
successful reset-load reading exactly like one that reused the session, so
the caller had to probe a binding to tell them apart.

A reset-load now carries its own note: the session was reset, earlier
bindings are gone, and these packages were re-required. A load that reused
the session says nothing, which is the distinguishing signal. Both
directions are tested.

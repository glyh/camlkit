---
status: open
type: prototype
blocked-by: []
assignee:
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

Two constraints found while confirming it. The worker must be built in the
same switch as the project, because bytecode is version-locked. And this
cannot be folded into `eval`: changing the search path and using a module
from it in the same call fails, since nothing runs unless every phrase
typechecks first. That behaviour is pinned by a test.

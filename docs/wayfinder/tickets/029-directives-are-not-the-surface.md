---
status: resolved
type: decision
blocked-by: []
assignee: lyh
---

# Toplevel directives are not part of the tool surface

## Question

`eval` has rejected directives since
[Protocol between server and worker](015-worker-ipc.md), but it rejected them
as a typing problem and told the caller to use "a dedicated tool", which
implied the missing directives were a gap waiting to be filled. The fog entry
asked whether `#use`, `#load` and `#directory` should be reachable, as a
feature or as a boundary.

Decided: none of them. Directives are an interactive-toplevel affordance, not
an agent-facing one, and the surface stays as it is.

## Why

**The one directive an agent obviously wants is worse than its tool.**
`#require` swallows findlib errors into printed text, so a missing package
reports as a successful phrase with a sentence in its output. Calling
`Topfind` directly is why `require` can answer with `loaded` and `failed` as
arrays; see [Loading libraries into a session](007-library-loading.md).

**`load` is not expressible as directives.** It asks `dune top` for the
archives, adds the hidden `.objs/byte` directories findlib cannot see, and
retries until dependency order settles;
see [Loading a dune project's own libraries](021-dune-aware-load.md).
Exposing `#directory` and `#load` would hand that retry loop back to the
caller, over a surface that reports failure as prose.

**Directives cannot be pre-checked.** Evaluation types every phrase before
running any of them. A buffer containing a directive cannot be typed as
submitted, which is the argument already made in 015; admitting directives
means admitting partial execution.

**Not a security boundary.** Ticket [Trust boundary](012-trust-boundary.md)
already executes arbitrary OCaml deliberately, and `describe` interpolates
its argument into `#show %s;;`, so anything the ban excludes is reachable
anyway by someone trying. This is about the shape of the surface, not about
confinement.

## What changed

Only wording. `eval` already rejected directives; the rejection now says they
are not part of the surface and names the two operations that do have tools,
rather than implying every directive has one. The `eval` tool description says
the same.

## What is left

`#trace` is the only directive whose loss is a real capability loss rather
than a redundancy: `#use` is covered by evaluating the file's text with better
errors, and `[@@ocaml.toplevel_printer]` printers are installed automatically
by [Automatic toplevel printers](018-automatic-toplevel-printers.md). Tracing
a function stays in the fog. `Eval.directive` already exists, since `describe`
is a `#show` wrapper, so if it is ever wanted it is a tool declaration rather
than new machinery.

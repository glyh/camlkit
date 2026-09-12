---
status: resolved
type: research
blocked-by: [021]
assignee: lyh
---

# Evaluating in a file's context

## Question

Both of the Lisp clients surveyed evaluate inside an ambient namespace:
CIDER sends an `ns` with every op, SLY has `set-package` and
`sync-package-and-default-directory`. A fragment lifted out of a file
therefore resolves the way the file does. Nothing here corresponded. `load`
makes a project's modules reachable, and that is all: a session evaluating
code copied out of `lib/merlin.ml` saw none of that file's `open`s, was not
inside `Merlin`, and did not have dune's wrapper module open either.

The agent's normal move is exactly that copy. So it either qualified every
name by hand, guessing at the wrapper, or read more source until it could.

## What a context is made of

Three parts, and the first two are the ones an agent cannot guess:

1. **Dune's `-open`**, the wrapper module for a wrapped library. merlin is
   asked for this rather than derived: `ocamlmerlin single dump-configuration`
   reports it as `ocaml.open_modules`. Measured on `lib/merlin.ml` in this
   project, which returns `["Camlkit"]`.
2. **The file's own module**, so its earlier definitions are reachable
   unqualified, which is what a fragment from the middle of a file expects.
   That is the wrapper plus the file's module name.
3. **The file's own `open` statements**, in source order.

Both opens were measured to work in a loaded session before anything was
built, which is the whole mechanism:

    load { path = <project root> }         -> ok
    open Camlkit;;                         -> ok
    open Camlkit.Merlin;;                  -> ok

## Decided

**A tool that answers with the preamble, not an argument on `eval` that
applies it.** The ticket leaned the other way and the leaning was wrong, for
two reasons found while building it.

An `open` is ordinary session state. Evaluated once, it holds for every later
call in that session, so there is nothing for `eval` to carry per call and
nothing to decide about stickiness - the answer that ticket 019 had to reach
for autorun does not arise here. The per-call form would repeat the same work
on every call to express something the session already remembers.

And prepending to the caller's source would shift every line, which breaks the
spans that tickets 004 and 034 are about. Keeping them honest means sending
the preamble beside the source rather than inside it, which is a new field in
the IPC message, a preamble pass in the worker, and a decision about what
all-or-nothing means across two batches. The tool is a branch in the
session-less dispatch and a module, and it composes with the preamble `reset`
already takes, see ticket 031: reset with these opens is "start this session
in that file's context" with nothing added.

**The wrapper is asked of merlin, not derived.** Deriving it means knowing
which `dune` stanza a file belongs to and whether it is wrapped, which is
re-implementing what merlin's configuration already carries.

**A file's own module is offered only when there is a wrapper.** Without one
the file is an executable's module or an unwrapped library's, which a session
cannot name at all, so offering the open would hand back a preamble that
fails. Measured on `bin/main.ml` here: `open_modules` is empty, and what comes
back is that file's own two opens and nothing invented.

**The file is the wrapper.** `lib/camlkit.ml` would give `Camlkit.Camlkit`,
so a file whose module name equals the wrapper gets no own-module open.

**The file's own opens are scanned, not parsed.** A toplevel `open` sits at
column zero and a nested one is indented; that is the whole heuristic, and
`open struct` does not match because a module path starts with a capital. The
alternative is linking compiler-libs into the server for one regular
expression. Marked as a `ponytail:` ceiling in `lib/context.ml`.

**The answer is code, and the structure is the paths.** Text is `open X;;`
lines ready to evaluate or to hand to `reset`; `structuredContent` carries the
module paths in order. Two shapes rather than one restated, which is what
ticket 004 asks for.

## Checked

`context of a file` and `context of a missing file` in the server suite, over
a standalone file: the file's own opens in order, nothing nested, nothing
invented, and a missing file as a negative answer rather than `isError`.

The wrapper half needs a real dune project, and merlin finds a project's
configuration by invoking dune, which will not run inside dune. So it lives in
`scripts/load-check.py` beside the loader check, which asks for the context of
`lib/render.ml`, evaluates it in a loaded session, and uses a name from
`Render` unqualified.

## Not this

Making the session actually be inside the module rather than opening it. There
is no such thing in the toplevel, and shadowing is what `open` is for.

An open that reaches a definition added since the last build. The preamble
opens the built module, so a fragment referring to something newer fails as an
unbound name. Saying "stale build" instead would mean knowing what the build
tree holds versus what the buffer does, which is a question for whatever built
it.

---
status: open
type: research
blocked-by: [021]
assignee:
---

# Evaluating in a file's context

## Question

Both of the Lisp clients surveyed evaluate inside an ambient namespace:
CIDER sends an `ns` with every op, SLY has `set-package` and
`sync-package-and-default-directory`. A fragment lifted out of a file
therefore resolves the way the file does. Nothing here corresponds. `load`
makes a project's modules reachable, and that is all: a session evaluating
code copied out of `lib/merlin.ml` sees none of that file's `open`s, is not
inside `Merlin`, and does not have dune's wrapper module open either.

The agent's normal move is exactly that copy. So it either qualifies every
name by hand, guessing at the wrapper, or reads more source until it can. The
failure is not subtle - it is `Unbound module` on a name the file uses on
every line - but it costs a round trip each time and the agent has no way to
know what the right prefix was.

## What a context is made of

Three parts, and the first two are the ones an agent cannot guess:

1. **Dune's `-open`**, the wrapper module for a wrapped library. `merlin` is
   asked for this rather than derived: `ocamlmerlin single dump-configuration`
   reports it as `ocaml.open_modules`. Measured on `lib/merlin.ml` in this
   project, which returns `["Camlkit"]`.
2. **The file's own module**, so its earlier definitions are reachable
   unqualified, which is what a fragment from the middle of a file expects.
   That is the wrapper plus the file's module name.
3. **The file's own `open` statements**, in source order.

## Measured

Both opens work in a loaded session, which is the whole mechanism:

    load { path = <project root> }         -> 11 libraries
    open Camlkit;;                         -> ok
    open Camlkit.Merlin;;                  -> ok

So there is nothing to invent. The question is only where the prefix is
assembled and how a caller asks for it.

## Open

**Where it goes.** Either a `context` argument on `eval` naming a file, with
the server assembling the opens and the worker prepending them, or a separate
tool that returns the opens for a file and leaves the caller to send them.
The first is one call instead of two and matches "a call says only what is
unusual"; the second adds nothing to the eval path and is trivially testable.
Leaning first.

**Per call or per session.** A context is sticky in both CIDER and SLY, and
that is right for a human working in one file for an hour. It is likely wrong
here for the reason ticket 019 gave when autorun moved from the session to
the call: a session whose behaviour depends on a call nobody remembers. Per
call, then, and the cost is repeating the file name.

**Whether the file's own `open`s need merlin at all.** The toplevel ones are
a parse away, and `Parse.implementation` is already linked in the worker. A
nested `open` inside the module the fragment came from would need the typed
tree, and is probably not worth it.

**What a fragment that names its own module does.** Opening `Camlkit.Merlin`
brings in what the *built* module has, not what an edited buffer has. A
fragment referring to a definition added since the last build fails, and
should say so as a stale-build problem rather than an unbound name.

## Not this

Making the session actually be inside the module, rather than opening it.
There is no such thing in the toplevel, and shadowing is what `open` is for.

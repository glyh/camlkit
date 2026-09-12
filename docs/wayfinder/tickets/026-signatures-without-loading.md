---
status: closed
type: research
blocked-by: [027]
assignee: lyh
---

# Module signatures without loading

## Question

`describe` answers from the live toplevel, so it only sees what a session has
loaded. Asking what is in a library means loading it first, which needs the
project built and the right switch.

[ocaml-mcp](https://github.com/tmattio/ocaml-mcp) reads signatures from
compiled artifacts instead, and its TODO sketches a fuller ladder: use merlin
if the module is part of the project; look in `_build/private/.pkg` if the
project uses dune package management; look at the installed files through
findlib otherwise; and fall back to `docs-data.ocaml.org` for a package that
is not installed at all.

## Decided

**Local rungs only. No network.** Reaching `docs-data.ocaml.org` would make
this the one part of the server that talks to the network, and
[Trust boundary](012-trust-boundary.md) rests on everything staying beside
the person who launched it. A signature for a package you have not installed
is not worth changing that.

**Blocked on merlin**, which is the first rung: once
[Merlin-backed source queries](027-merlin-source-queries.md) lands, project
modules are covered and `describe` covers anything a session has loaded. What
remains is the installed-but-not-loaded case through findlib, which may turn
out to be small enough not to need a ticket at all.

**Dune package management is not a rung.** `_build/private/.pkg` only exists
for a project that uses dune's own package management, and for such a project
`load` already puts the dependencies in a session, where `describe` answers.
A rung that is only reachable when the rung below it already works is not
worth its code.

## Done

The `signature` tool, session-less like the merlin ones: a path such as
`Yojson.Safe.to_string` and, optionally, the findlib package holding it.

**The switch's own toplevel, shelled out, rather than reading the .cmi here.**
`#directory` puts the package's recursive findlib directories on the search
path and `#show` prints the item; nothing is linked, no initialiser runs and
no C stub is needed, which is the whole point of answering without loading.
Reading interfaces directly was the alternative: it means linking
compiler-libs into the native server, then reimplementing what `#show` does -
resolving a dotted path through nested signatures, and printing a module, a
value, a type, an exception or a class. That is the same trade as merlin in
[Merlin-backed source queries](027-merlin-source-queries.md), decided the same
way, and it also keeps the answer identical to what `describe` returns for a
package a session has loaded.

**Recursive directories, not just the package's own.** A signature names types
from the package's dependencies, and `#show` cannot print what it cannot find,
so `ocamlfind query -r` supplies the path.

**The package is guessed from the path when it is not given.** Most packages
are named after their top module, so requiring both would be a lookup the
caller usually does not need. A wrong guess says it was a guess and names what
it tried, because the failure is otherwise indistinguishable from a package
that is genuinely absent. It says so in a `guessed` field as well as in the
text: the retry that fixes it is naming the package, and a caller acting on
the fields alone cannot know to try that otherwise. That is the structural
contract in [What an eval returns to the agent](004-eval-result-contract.md) -
a failure names the thing that failed in a field rather than only inside a
sentence.

**A missing package or path is not `isError`.** It is a negative answer to a
well-formed question, which the trust contract in
[MCP semantics to target](002-mcp-wire-contract.md) reserves `isError` against.
It comes back as an `error` field instead, in place of `signature`.

**The path is spliced into a toplevel script, so it is checked first.** A
quote, a backslash, a newline or a semicolon is refused: not a security
boundary, since this server evaluates whatever it is given anyway, but a
mistyped path should fail as a bad path rather than as a second phrase.

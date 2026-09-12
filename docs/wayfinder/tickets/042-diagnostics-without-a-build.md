---
status: open
type: research
blocked-by: [027]
assignee:
---

# Diagnostics without a build

## Question

An agent that has just edited a file wants to know whether it compiles.
Today the only answer is `dune build` in its own shell, which
[Building the project from a tool](025-build-from-a-tool.md) decided was
enough and removed the build tool over. That decision still holds for
building. It does not cover this: a build answers about the project after
writing the file, takes as long as the project takes, and cannot answer at all
while some other part of the project is broken.

merlin's `errors` answers about one file, in milliseconds, from the source
handed to it rather than the source on disk.

## Measured

On a real project file, with the file's actual configuration and no build,
feeding merlin an edited copy of `lib/context.ml` under the real file's name:

    typer, line 67 col 71: The value opens has type int but an expression was
                           expected of type string list
    26 ms

On a standalone file, two errors at once, each with position, end position,
severity class and sub-messages:

    typer  1:18  The value x has type int but an expression was expected of
                 type string
    typer  2:8   Unbound value List.mapp
                 sub: Hint: Did you mean List.map, List.map2 or List.mapi?

That shape is already the shape this project reports errors in: spans and line
ranges as data, the message beside them, per
[What an eval returns to the agent](004-eval-result-contract.md). The hint in a
sub-message is worth carrying rather than flattening, since "did you mean" is
the whole answer for a typo.

The unsaved-edit case is the one that has no substitute anywhere else on the
surface, and it costs nothing extra: merlin reads the source from stdin, which
`Merlin.query` already does, so the only new thing is where that source comes
from.

## Open

**Whether it takes the edited source at all.** Every merlin tool here reads
the file from disk and sends it. Accepting a `source` argument instead is what
makes this answer about an edit that has not been written, which is the
interesting half. Against: nothing else on the surface takes code that is not
in a file, and an agent that has not written the file yet could write it.

**Warnings.** merlin reports them through the same list with a different
class. A caller wants them separated, the way `eval` separates warnings from
errors rather than interleaving them.

**Not a build.** This answers about one file against what is already compiled.
It will not notice that a dependency needs rebuilding, and it must not claim
to. The description has to say so, or it becomes a build tool that lies.

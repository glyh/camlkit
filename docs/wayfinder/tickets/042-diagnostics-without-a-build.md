---
status: resolved
type: research
blocked-by: [027]
assignee: lyh
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

## Decided

**It takes the edited source, which was the question the ticket turned on.**
`source` is optional and replaces what the file holds; the file is still named,
because that is how merlin finds the configuration to type against. Reproduced
on `lib/context.ml` with an edit never written to disk: the same error at
67:71 the ticket measured.

The argument against was that an agent could write the file first. True, and
it would also mean writing a broken file to ask whether it is broken. Every
merlin tool here already sends the file's contents down the pipe, so this
changes only where they come from - three lines in `Merlin.query`.

**Warnings come back apart from errors.** merlin answers one list with a
`type` on each entry, "warning" among "typer", "parser" and the rest. The
split happens in `Merlin.diagnostics` rather than in the caller's head, the
way an eval result keeps the two apart.

**The entries are trimmed.** `valid` is true on everything returned, `type` is
said by which list an entry is in, and `sub` is almost always empty. What
survives is the message and the range.

**The text half is lines, not JSON.** The structure beside it carries the same
thing as fields, so pretty-printed JSON in the text would be the same content
twice in the shape a reader wants least.

**Both fields are absent when empty,** so a clean file costs a sentence.

## Measured again, on this switch

Timing, median of five: 12 ms for a standalone file, 43 ms for a real project
file with its configuration. The ticket's original 26 ms was on other hardware
and a different project; the order of magnitude holds.

The hint is still inside the message rather than in `sub` on merlin 5.5
- `Unbound value List.mapp\nHint: Did you mean map, map2 or mapi?` - so
passing the message through keeps it, and nothing has to flatten `sub`.

## Open

**Not a build, and the description says so** in two sentences: it types one
file against what is already compiled around it, so it cannot report that a
dependency needs rebuilding, and a clean answer here is not a passing build.
That wording is the whole defence against this becoming a build tool that
lies, and it should not be shortened.

**Whether a caller will pass a stale `source`.** Nothing stops an agent
sending text that no longer matches its own buffer, and the answer's positions
would then point into text nobody has. Not defended against: the same is true
of every tool that takes a path and reads the file a moment later.

Covered by "diagnostics without a build" in the server suite: a clean file
carries neither field, an unsaved edit with one error and one warning comes
back with them apart and positions into the edit, and the file on disk is
unchanged by having been asked about.

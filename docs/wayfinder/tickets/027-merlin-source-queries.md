---
status: closed
type: prototype
blocked-by: []
assignee: lyh
---

# Merlin-backed source queries

## Question

Three questions a toplevel cannot answer, because they are about source
rather than about values: where is this defined, what is its type at this
position, and where else is it used.

Investigated already, and the interface is small. `ocamlmerlin <single|server>
<command> [-position L:C] -filename <path> < source`, one JSON envelope for
every command with `class` and `value`. Source arrives on stdin, so it
analyses unsaved buffers. `single` costs about 30 ms per query and `server`
about 2 ms, with identical arguments. dune already writes the `.merlin-conf`
these need.

Measured working: `locate` resolved a symbol to its file and line, `outline`
returned kind and name per item, `type-enclosing` returned types innermost
first with ranges.

## Decided

**Five commands**: `locate`, `type-enclosing`, `outline`, `occurrences`, and
type search via `search-by-polarity`. The first three are the ones a toplevel
cannot answer at all; occurrences and type search are exploration primitives
with no equivalent here. `case-analysis` and `construct` are editing
operations and stay out.

Use `server` mode, not `single`: identical arguments, 2 ms against 30 ms.

The cost is a second subsystem and a runtime dependency on the `ocamlmerlin`
binary, which is version-matched to the compiler the same way the worker is.

## Resolution

Five tools, none of which take a session: `locate`, `type_at`, `outline`,
`uses`, `search_type`. They ask about code as written, so they need nothing
built and nothing loaded, and they answer inside the call rather than going
through a worker.

Shelled out rather than linked. `merlin-lib` exists, but its internal
libraries are far less stable than the documented CLI, and that coupling is
what has bitten repeatedly here. Server mode, for the 2 ms against 30.

`ocamlmerlin` is looked for beside our own executable before PATH, the same
as dune, because we install into a switch where it lives and a client may
spawn us with neither on PATH.

Merlin already answers in structure, so the value is passed through under a
name saying what it is, rather than reshaped.

**The test fixture is written outside the project deliberately.** Merlin
finds a dune project's configuration by invoking dune, which would contend
for the build lock while `dune runtest` holds it. This is the same trap that
`dune top` hit in
[Loading a dune project's own libraries](021-dune-aware-load.md), met a second
time from a different direction. A standalone file needs no configuration
beyond the stdlib, so the tests query one written to a temp directory.

Verified live against this repository as well: `outline` listed the
definitions of a module, `locate` resolved a call into the stdlib's
`unix.mli`, and `type_at` returned the enclosing types innermost first.

## Amendment: project-wide occurrences were silently partial

Reported from a session using it on a real project. Asking for uses of a
function returned 26 occurrences, all inside its own file, and the reader
reasonably concluded it was unused elsewhere. `grep` found a 27th in a test.
After `dune build @ocaml-index`, the same call returned all 27.

**merlin gives no signal whatsoever.** Checked directly: without the index a
project-scope query answers `class: return`, `notifications: []`, and a list
that is simply short. Nothing distinguishes it from a complete answer, which
is what makes this the dangerous kind of bug rather than a missing feature.

**`uses` now builds the index itself** before a project-scope query. Measured
at 0.2 s once the project is otherwise built, which is worth paying: a wrong
answer that looks complete is worse than a slow one. Verified from zero index
files to twenty occurrences across three files.

When the index cannot be built - a file outside any dune project, for
instance - the result carries `complete: false` and a caveat naming the
command, and the text half leads with INCOMPLETE. Tested both ways.

**`search_type` needs qualified type names**, which the same report worked
out the hard way: `Core.term -> string` finds things that bare `term` does
not, even in a file whose first line opens `Core`, because merlin matches
against its own environment rather than the buffer's. Not ours to fix, but
the tool description now says so.

## Amendment: duplicate entries from merlin, papered over

Reported from a session, and both confirmed to be upstream rather than ours.

`type-enclosing` returns the innermost enclosing twice when one source range
maps to two typedtree nodes, which is common for an identifier in an
application position. Reproduced directly against merlin at
`lib/session.ml` 41:24: the first two entries are byte-identical, same range
and same type. `search-by-type` returns a value twice when two paths to it
collapse to one location.

Exact duplicates are dropped at this layer, marked `HACK:` in
`bin/main.ml` with the condition for removing it. The reasoning for why that
is safe rather than lossy came from the report and is worth keeping: a repeat
is indistinguishable from the first, because enclosings are strictly nested
so two identical ranges cannot both be meaningful, and two hits at one file
position are the same hit. An exact duplicate carries no information, so
removing it loses none; it only costs the reader context and confidence.

A regression covers it, and would still pass once merlin stops emitting them,
which is the signal that the hack can go.

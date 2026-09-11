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

---
status: open
type: prototype
blocked-by: []
assignee:
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

---
status: open
type: grilling
blocked-by: [002, 003]
assignee:
---

# What an eval returns to the agent

## Question

utop reports parse verdict and error spans on `accept:`, but sends
warnings, type errors and runtime exception traces all on `stderr:`,
while values land on `stdout:`. An agent consuming this needs to tell a
compile error from a warning from a runtime failure, because the next
action differs in each case.

Two parts of this are already settled by
[MCP semantics to target](002-mcp-wire-contract.md): a failed phrase is an
ordinary result, never an `isError`, and the tool declares an
`outputSchema` so results carry `structuredContent`.

What remains is the field-level detail. What the schema's fields actually
are, how warnings are separated from errors given that utop sends both on
`stderr:`, how the error spans on `accept:` map back onto the submitted
source, and how the `_N` implicit bindings are surfaced.

Needs real captures from the session driver to decide against, not
guesses, and cannot be settled before the MCP result shape is pinned,
since whatever is decided here has to be expressed in it.
